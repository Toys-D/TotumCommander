import CoreServices
import Foundation

/// Что пришло в папки — по журналу изменений диска (FSEvents), не дожидаясь Spotlight.
///
/// Spotlight узнаёт о переносе с большим опозданием: файл, брошенный в подпапку, и через
/// двадцать минут числился у него на старом месте. Журнал знает сразу — и помнит: слежка за
/// папкой (FolderNewsStream) при входе дочитывает его за срок новизны. Список общий для обеих
/// панелей и живёт всю сессию. Только файлы и пакеты (документ .pages, программа) — не папки и
/// не то, что внутри пакетов; скрытое не в счёт.
final class FolderNewsArrivals: @unchecked Sendable {
    static let shared = FolderNewsArrivals()
    /// Список изменился. userInfo: `paths` — что пришло или ушло из списка, `gone` — чего на
    /// месте больше нет (Spotlight может ещё числить это там).
    static let changed = Notification.Name("fcxl.folderNewsArrivals")
    /// Дольше недели не держим: столько новизна не длится.
    static let keep: TimeInterval = 7 * 24 * 3600
    /// Больше не держим: при переполнении забываются самые старые.
    static let capacity = 20_000

    private let lock = NSLock()
    private var files: [String: Date] = [:]
    private var packages: [String: Bool] = [:]
    private var read: [String: (from: FSEventStreamEventId, until: FSEventStreamEventId)] = [:]

    private enum Found {
        case fresh(Date)
        case other
        case gone
    }

    /// Посмотреть на файлы: пришёл за неделю — запомнить, ушёл или не новый — забыть.
    /// С любого потока; уведомление — одно на пачку.
    func note(_ paths: [String], now: Date = Date()) {
        var changed: [String] = []
        var gone: [String] = []
        for path in paths {
            let found = look(at: path, now: now)
            lock.lock()
            switch found {
            case .fresh(let added):
                if files[path] != added {
                    files[path] = added
                    changed.append(path)
                }
            case .other, .gone:
                if files.removeValue(forKey: path) != nil { changed.append(path) }
            }
            lock.unlock()
            if case .gone = found { gone.append(path) }
        }
        trimIfFull()
        guard !changed.isEmpty || !gone.isEmpty else { return }
        NotificationCenter.default.post(name: Self.changed, object: nil,
                                        userInfo: ["paths": changed, "gone": gone])
    }

    private func look(at path: String, now: Date) -> Found {
        guard !path.contains("/.") else { return .other }
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .gone : .other }
        guard info.st_flags & UInt32(UF_HIDDEN) == 0 else { return .other }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: guard isPackage(path) else { return .other }
        default: return .other
        }
        guard !insidePackage(path),
              let added = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                .addedToDirectoryDate,
              now.timeIntervalSince(added) < Self.keep
        else { return .other }
        return .fresh(added)
    }

    /// Внутри пакета — части одного целого, а не отдельные новые файлы. У пакетов всегда есть
    /// расширение, так что спрашивать приходится только о таких папках, и ответ запоминается.
    private func insidePackage(_ path: String) -> Bool {
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if !(parent as NSString).pathExtension.isEmpty, isPackage(parent) { return true }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }

    private func isPackage(_ folder: String) -> Bool {
        lock.lock()
        let known = packages[folder]
        lock.unlock()
        if let known { return known }
        let package = (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        lock.lock()
        if packages.count > 10_000 { packages = [:] }
        packages[folder] = package
        lock.unlock()
        return package
    }

    private func trimIfFull() {
        lock.lock()
        defer { lock.unlock() }
        guard files.count > Self.capacity else { return }
        let oldest = files.sorted { $0.value < $1.value }.prefix(files.count - Self.capacity * 9 / 10)
        for (path, _) in oldest { files.removeValue(forKey: path) }
    }

    /// Что пришло внутрь папки (на любой глубине) не раньше `since`.
    func entries(under folder: String, since: Date) -> [(path: String, added: Date)] {
        let bases = Self.bases(of: folder)
        lock.lock()
        defer { lock.unlock() }
        return files.compactMap { path, added in
            guard added >= since, bases.contains(where: { path.hasPrefix($0) }) else { return nil }
            return (path, added)
        }
    }

    /// Папка как префикс: и путь панели, и настоящий (Spotlight и FSEvents отдают настоящие).
    static func bases(of folder: String) -> [String] {
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        let real = FolderNews.realPath(folder)
        let realBase = real.hasSuffix("/") ? real : real + "/"
        return base == realBase ? [base] : [base, realBase]
    }

    /// Какой кусок журнала по папке уже прочитан — при возвращении в неё дочитывается только
    /// новое. Без этого вход в домашнюю папку каждый раз перечитывал бы сотни тысяч событий.
    func readRange(of folder: String) -> (from: FSEventStreamEventId, until: FSEventStreamEventId)? {
        lock.lock()
        defer { lock.unlock() }
        return read[folder]
    }

    func markRead(_ folder: String, from: FSEventStreamEventId, until: FSEventStreamEventId) {
        lock.lock()
        read[folder] = (from, until)
        lock.unlock()
    }

    func forgetAll() {
        lock.lock()
        files = [:]
        packages = [:]
        read = [:]
        lock.unlock()
    }
}

/// Слежка за деревом папки по журналу FSEvents: с истории за срок новизны — и дальше вживую, в
/// том числе пока программа в фоне (слежка панели тогда спит, а файлы бросают через Finder).
/// Что пришло, ушло или переименовано — в FolderNewsArrivals; правка содержимого — не новость.
final class FolderNewsStream {
    /// Журнал глубже суток не читается: сутки в домашней папке — это ~800 тысяч событий и
    /// секунды работы. Что старше — знает Spotlight.
    static let historyLimit: TimeInterval = 24 * 3600
    static let latency: CFTimeInterval = 0.5

    let folder: String
    private let stream: FSEventStreamRef
    private let queue: DispatchQueue
    private let from: FSEventStreamEventId
    private var stopped = false

    init?(folder: String, period: TimeInterval, queue: DispatchQueue, now: Date = Date()) {
        let wanted = Self.eventID(before: now.addingTimeInterval(-min(period, Self.historyLimit)), on: folder)
        var since = wanted
        var from = wanted
        if let read = FolderNewsArrivals.shared.readRange(of: folder), read.from <= wanted {
            // Уже прочитанное с нужного места — дочитать после него; прочитанным станет всё сразу.
            since = max(wanted, read.until)
            from = read.from
        }
        var context = FSEventStreamContext()
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context,
                                               [folder as CFString] as CFArray, since, Self.latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.folder = folder
        self.stream = stream
        self.queue = queue
        self.from = from
    }

    /// Последнее событие журнала до этого времени — с него и читать. Время — от 1970 года, как
    /// у time_t, хоть тип и CFAbsoluteTime (так в FSEvents.h).
    static func eventID(before date: Date, on folder: String) -> FSEventStreamEventId {
        var info = stat()
        guard stat(folder, &info) == 0 else { return FSEventStreamEventId(kFSEventStreamEventIdSinceNow) }
        return FSEventsGetLastEventIdForDeviceBeforeTime(info.st_dev, date.timeIntervalSince1970)
    }

    /// Пришёл, ушёл, переименован, склонирован (так копирует Finder на APFS).
    private static let arrivalFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCloned)

    private static let callback: FSEventStreamCallback = { _, _, count, rawPaths, flags, _ in
        let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var batch = Set<String>()
        for index in 0..<count where flags[index] & FolderNewsStream.arrivalFlags != 0 {
            // Скрытое по имени (.git, .build) — мимо, не превращая в строку: при сборке таких
            // событий тысячи.
            guard strstr(paths[index], "/.") == nil else { continue }
            batch.insert(String(cString: paths[index]))
        }
        if !batch.isEmpty { FolderNewsArrivals.shared.note(Array(batch)) }
    }

    /// Остановить и запомнить, докуда журнал прочитан. Остановка — на очереди слежки: там
    /// может как раз идти разбор пачки.
    func stop() {
        guard !stopped else { return }
        stopped = true
        let stream = stream, folder = folder, from = from
        queue.async {
            let until = FSEventStreamGetLatestEventId(stream)
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            FolderNewsArrivals.shared.markRead(folder, from: from, until: until)
        }
    }

    deinit { stop() }
}
