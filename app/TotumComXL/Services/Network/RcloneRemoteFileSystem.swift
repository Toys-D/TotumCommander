import Foundation

/// Хранилище, настроенное в rclone, как обычная панель: Google Drive, Dropbox, OneDrive,
/// Яндекс.Диск, Box, pCloud — всё, что rclone умеет, а умеет он семь десятков штук.
///
/// Ключи и пароли к этим хранилищам здесь не спрашиваются и не хранятся: они уже лежат в
/// настройке rclone, куда человек их положил командой `rclone config`. Мы называем хранилище
/// по имени — «мойдиск» — и дальше говорим только про пути.
///
/// Все действия идут через служебный сервер rclone (см. `RcloneDaemon`). Долгие — перенос
/// файла — запускаются отдельным заданием, чтобы показывать полосу и слушаться отмены:
/// без этого копирование гигабайта выглядело бы как зависшая программа.
final class RcloneRemoteFileSystem: RemoteFileSystemProtocol {

    private let connection: RemoteConnection
    private let daemon: RcloneDaemon
    private(set) var isConnected = false
    /// Наше место у помощника — по нему же его и отпускаем.
    private var ticket: Int?

    var protocolDisplayName: String { "rclone" }
    var rootPath: String { "/" }

    /// `operations/purge` сносит папку со всем содержимым одним обращением — обходить
    /// дерево самим значит слать запрос на каждый файл.
    var deletesTreesItself: Bool { true }

    /// rclone переносит файл целиком и с обрыва начинает заново — продолжить с середины
    /// он не даст. Честнее сказать это сразу, чем просить его о невозможном.
    var supportsResume: Bool { false }

    init(connection: RemoteConnection, daemon: RcloneDaemon = .shared) {
        self.connection = connection
        self.daemon = daemon
    }

    // MARK: - Имена и пути

    /// Как хранилище зовётся у rclone. Двоеточие на конце обязательно: без него rclone
    /// принял бы имя за папку на этом компьютере.
    private var fs: String { connection.rcloneRemote + ":" }

    /// Путь внутри хранилища. Внутри программы пути начинаются со слэша, у rclone — нет.
    static func remotePath(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private func remote(_ path: String) -> String { Self.remotePath(path) }

    /// Разложить путь на «где» и «что» — этого просят все переносы rclone: папка отдельным
    /// полем, имя отдельным.
    static func split(_ path: String) -> (directory: String, name: String) {
        let clean = remotePath(path)
        guard let slash = clean.lastIndex(of: "/") else { return ("", clean) }
        return (String(clean[clean.startIndex..<slash]),
                String(clean[clean.index(after: slash)...]))
    }

    // MARK: - Подключение

    func connect() async throws {
        guard !connection.rcloneRemote.isEmpty else {
            throw RemoteFileSystemError.connectionFailed(L("rclone.error.noRemoteChosen"))
        }
        let place = try await daemon.acquire()
        ticket = place.ticket
        do {
            // Проверка, что такое хранилище у rclone действительно есть и открывается:
            // ошибка здесь — это «нет такого имени» или «пропуск протух», и человеку надо
            // сказать об этом сейчас, а не при первом же списке файлов.
            _ = try await daemon.call("operations/fsinfo", ["fs": fs])
        } catch {
            await daemon.release(place.ticket)
            ticket = nil
            throw error
        }
        isConnected = true
    }

    func disconnect() {
        guard isConnected, let place = ticket else { return }
        isConnected = false
        ticket = nil
        Task { [daemon] in await daemon.release(place) }
    }

    /// Имена хранилищ, настроенных у человека в rclone. Нужны, чтобы предложить выбор,
    /// а не заставлять вспоминать имя наизусть.
    static func availableRemotes(daemon: RcloneDaemon = .shared) async throws -> [String] {
        let place = try await daemon.acquire()
        defer { Task { await daemon.release(place.ticket) } }
        let answer = try await daemon.call("config/listremotes", [:])
        return (answer["remotes"] as? [String] ?? []).sorted()
    }

    // MARK: - Список

    func listDirectory(at path: String) async throws -> [FileItem] {
        guard isConnected else { throw RemoteFileSystemError.notConnected }
        let answer = try await daemon.call("operations/list", [
            "fs": fs,
            "remote": remote(path),
            // Тип содержимого не спрашиваем: ради него rclone у некоторых хранилищ лезет
            // за каждым файлом отдельно, и список папки на тысячу имён едет минуту.
            "opt": ["noMimeType": true]
        ])
        let rows = answer["list"] as? [[String: Any]] ?? []
        let parent = path.hasSuffix("/") ? path : path + "/"
        return rows.compactMap { Self.item(from: $0, in: parent) }
    }

    /// Одна строка выдачи rclone в наш вид.
    ///
    /// Имя берётся из поля `Name`, а путь собирается от запрошенной папки. Поле `Path` тоже
    /// есть, но что именно в нём лежит — путь от корня хранилища или от запрошенной папки —
    /// у разных хранилищ выходит по-разному, и полагаться на него значит однажды получить
    /// «папка/папка/файл».
    static func item(from row: [String: Any], in parent: String) -> FileItem? {
        guard let name = row["Name"] as? String, !name.isEmpty else { return nil }
        let isDirectory = row["IsDir"] as? Bool ?? false
        let size = (row["Size"] as? NSNumber)?.int64Value ?? 0
        let date = (row["ModTime"] as? String).flatMap(Self.date(from:)) ?? Date()
        let dotted = (name as NSString).pathExtension

        return FileItem(
            path: parent + name,
            name: name,
            // У папки расширения не бывает, даже если в имени есть точка.
            fileExtension: isDirectory ? "" : dotted,
            size: isDirectory ? 0 : UInt64(max(0, size)),
            isDirectory: isDirectory,
            isHidden: name.hasPrefix("."),
            isSymlink: false,
            permissions: isDirectory ? "drwxr-xr-x" : "-rw-r--r--",
            dateModified: date,
            dateCreated: date,
            dateAdded: date,
            owner: "",
            entryCount: 0)
    }

    /// Время rclone отдаёт по RFC 3339, иногда с долями секунды, иногда без.
    static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: - Папки и имена

    func createDirectory(at path: String, name: String) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }
        let inside = remote(path)
        let full = inside.isEmpty ? name : inside + "/" + name
        try await daemon.call("operations/mkdir", ["fs": fs, "remote": full])
    }

    func deleteItem(at path: String, isDirectory: Bool) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }
        // Папку сносит purge — одним заданием со всем содержимым; rmdir потребовал бы,
        // чтобы она была пуста, и на непустой просто отказал бы.
        try await daemon.call(isDirectory ? "operations/purge" : "operations/deletefile",
                              ["fs": fs, "remote": remote(path)])
    }

    func rename(at path: String, to newName: String) async throws {
        let (directory, _) = Self.split(path)
        let target = directory.isEmpty ? newName : directory + "/" + newName
        try await move(from: remote(path), to: target)
    }

    func moveItem(from sourcePath: String, to destinationPath: String) async throws {
        try await move(from: remote(sourcePath), to: remote(destinationPath))
    }

    /// Переезд внутри одного хранилища — и для файла, и для папки.
    private func move(from source: String, to target: String) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }
        guard source != target else { return }

        // Файл или папка — узнаём у rclone, а не гадаем по имени: у папки может быть
        // точка в имени, а у файла её может не быть.
        let isDirectory = try await isDirectory(source)
        if isDirectory {
            // У папок отдельного «переименовать» нет: содержимое переезжает целиком,
            // а опустевший исходник убирается следом.
            try await daemon.call("sync/move", [
                "srcFs": fs + source,
                "dstFs": fs + target,
                "createEmptySrcDirs": true,
                "deleteEmptySrcDirs": true
            ])
            // Сам исходный каталог sync/move не трогает — только его содержимое.
            try? await daemon.call("operations/rmdir", ["fs": fs, "remote": source])
        } else {
            let from = Self.split(source)
            let to = Self.split(target)
            try await daemon.call("operations/movefile", [
                "srcFs": fs, "srcRemote": from.directory.isEmpty
                    ? from.name : from.directory + "/" + from.name,
                "dstFs": fs, "dstRemote": to.directory.isEmpty
                    ? to.name : to.directory + "/" + to.name
            ])
        }
    }

    /// Дождаться, пока остановленное задание действительно встанет. Не навсегда: если
    /// rclone почему-то не отзывается, лучше отпустить человека, чем держать его в
    /// заморозке из-за отмены, которую он же и попросил.
    private func waitUntilStopped(_ job: Int64) async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let status = (try? await daemon.call("job/status", ["jobid": job])) ?? [:]
            if status["finished"] as? Bool == true { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Папка ли это. Отдельный вопрос к хранилищу — зато без догадок.
    private func isDirectory(_ path: String) async throws -> Bool {
        let answer = try await daemon.call("operations/stat", ["fs": fs, "remote": path])
        guard let item = answer["item"] as? [String: Any] else {
            throw RemoteFileSystemError.pathNotFound(path)
        }
        return item["IsDir"] as? Bool ?? false
    }

    /// Размер файла в хранилище — нужен полосе, чтобы показывать долю, а не голые байты.
    private func size(of path: String) async throws -> Int64 {
        let answer = try await daemon.call("operations/stat", ["fs": fs, "remote": path])
        guard let item = answer["item"] as? [String: Any] else {
            throw RemoteFileSystemError.pathNotFound(path)
        }
        return (item["Size"] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Перенос

    func download(remotePath: String, to localPath: String,
                  progress: @escaping (Int64, Int64) -> Bool) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }
        let source = remote(remotePath)
        // Размер не спрашиваем: это лишний поход к хранилищу перед каждой загрузкой, а
        // rclone всё равно сообщает его в ходе работы — у документов Google только так его
        // и узнать, потому что до начала выгрузки его не знает и сам Диск.
        let total: Int64 = 0
        let destination = (localPath as NSString).deletingLastPathComponent
        let name = (localPath as NSString).lastPathComponent

        try await copy(arguments: [
            "srcFs": fs, "srcRemote": source,
            "dstFs": destination, "dstRemote": name
        ], total: total, progress: progress)
    }

    func upload(localPath: String, to remotePath: String,
                progress: @escaping (Int64, Int64) -> Bool) async throws {
        guard isConnected else { throw RemoteFileSystemError.notConnected }
        let attributes = try? FileManager.default.attributesOfItem(atPath: localPath)
        let total = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let source = (localPath as NSString).deletingLastPathComponent
        let name = (localPath as NSString).lastPathComponent

        let arguments: [String: Any] = [
            "srcFs": source, "srcRemote": name,
            "dstFs": fs, "dstRemote": remote(remotePath)
        ]
        do {
            try await copy(arguments: arguments, total: total, progress: progress)
        } catch let error as RemoteFileSystemError where Self.needsGoogleImport(error) {
            // Назначение — родной документ Google (Docs/Sheets/Slides). Это не файл:
            // перезаписать его байтами Диск не даёт, требует ВВОЗА — преобразования файла
            // обратно в документ. rclone умеет, но только с ключом import_formats, поэтому
            // тот же перенос повторяется с ним. Человек видел здесь «не удалось отправить»
            // на правках, которые сам же сохранил, — а спасало дело одно повторение.
            let ext = (remotePath as NSString).pathExtension
            guard !ext.isEmpty else { throw error }
            var retry = arguments
            retry["dstFs"] = Self.importFs(remote: connection.rcloneRemote,
                                           fileExtension: ext)
            try await copy(arguments: retry, total: total, progress: progress)
        }
    }

    /// Жалоба Диска на попытку перезаписать родной документ Google обычным файлом.
    static func needsGoogleImport(_ error: RemoteFileSystemError) -> Bool {
        (error.errorDescription ?? "").contains("can't update google document type")
    }

    /// Имя хранилища с ключом ввоза одного расширения: «Google Drive,import_formats=docx:».
    /// Одно расширение, а не список: в списке нужны запятые, а запятая в строке подключения
    /// rclone — разделитель ключей.
    static func importFs(remote: String, fileExtension ext: String) -> String {
        remote + ",import_formats=" + ext.lowercased() + ":"
    }

    /// Перенос одного файла заданием, с полосой и отменой.
    ///
    /// Обычным вызовом rclone ответил бы только по окончании: на гигабайте это минуты
    /// молчания, без единой цифры и без возможности передумать. Поэтому задание
    /// запускается отдельно (`_async`), помечается своим именем (`_group`) — и по этому
    /// имени у rclone спрашивается, сколько байт уже прошло.
    private func copy(arguments: [String: Any], total: Int64,
                      progress: @escaping (Int64, Int64) -> Bool) async throws {
        let group = "totum-" + UUID().uuidString
        var request = arguments
        request["_async"] = true
        request["_group"] = group

        let started = try await daemon.call("operations/copyfile", request)
        guard let job = (started["jobid"] as? NSNumber)?.int64Value else {
            throw RemoteFileSystemError.transferFailed(L("rclone.error.noJob"))
        }

        _ = progress(0, total)
        while true {
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Просмотр бросают, едва курсор уехал на другой файл. Задание при этом надо
            // снимать, а не оставлять: у rclone мест под переносы всего несколько, и
            // брошенные выгрузки занимали бы их, пока человек листает папку.
            if Task.isCancelled {
                try? await daemon.call("job/stop", ["jobid": job])
                throw RemoteFileSystemError.transferCancelled
            }

            let stats = (try? await daemon.call("core/stats", ["group": group])) ?? [:]
            let done = (stats["bytes"] as? NSNumber)?.int64Value ?? 0
            let known = (stats["totalBytes"] as? NSNumber)?.int64Value ?? 0
            let cancelled = progress(done, total > 0 ? total : known)
            if cancelled {
                try? await daemon.call("job/stop", ["jobid": job])
                // Просьба остановиться — ещё не остановка: rclone дописывает то, что уже
                // читает. Уйти сразу значит вернуть управление тому, кто следом переименует
                // или удалит файл — прямо под руку работающему заданию.
                await waitUntilStopped(job)
                // Убирать за ним не надо: rclone пишет во временное имя и сам сносит
                // недописанное. Проверено на живом rclone в обе стороны. Своя уборка тут
                // была бы не страховкой, а бедой: отмена до первого байта нашла бы на месте
                // СТАРЫЙ файл, который человек собирался заменить, и снесла бы его.
                throw RemoteFileSystemError.transferCancelled
            }

            let status = try await daemon.call("job/status", ["jobid": job])
            guard status["finished"] as? Bool == true else { continue }

            // Задание доигралось. Пустая строка в `error` — обычное дело для успеха.
            let complaint = (status["error"] as? String) ?? ""
            if !complaint.isEmpty {
                throw RcloneDaemon.error(from: ["error": complaint], path: "operations/copyfile")
            }
            _ = progress(total > 0 ? total : done, total > 0 ? total : done)
            return
        }
    }
}
