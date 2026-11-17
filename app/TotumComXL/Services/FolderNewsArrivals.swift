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
        guard !FolderNewsPath.hasHiddenPart(path), !FileNewness.isExcluded(path) else { return .other }
        let facts: FolderNewsDisk.Facts
        switch FolderNewsDisk.facts(at: path) {
        case .facts(let found): facts = found
        case .gone: return .gone
        case .unknown: return .other
        }
        guard !facts.isHidden else { return .other }
        switch facts.kind {
        case .file: break
        case .folder: guard isPackage(path) else { return .other }
        case .other: return .other
        }
        guard !insidePackage(path) else { return .other }
        // Появился или перезаписан (FileNewness); пакет — как папка: только появление.
        guard let date = FileNewness.date(added: facts.added, modified: facts.modified,
                                          isFolder: facts.kind == .folder),
              now.timeIntervalSince(date) < Self.keep
        else { return .other }
        return .fresh(date)
    }

    /// Внутри пакета — части одного целого, а не отдельные новые файлы. У пакетов всегда есть
    /// расширение, так что спрашивать приходится только о таких папках, и ответ запоминается.
    ///
    /// Путь разбирается байтами за один проход (FolderNewsPath). Раньше он укорачивался по
    /// одной папке через NSString, и у каждой считалась длина в знаках: на событие уходило
    /// ~80 мкс, и при сборке проекта рядом журнал один занимал четверть процессорного времени
    /// программы.
    private func insidePackage(_ path: String) -> Bool {
        FolderNewsPath.foldersWithExtension(above: path).contains { isPackage($0) }
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
        waiting = []
        lock.unlock()
    }

    // MARK: - В фоне журнал только копит

    /// Сколько путей копится в фоне, прежде чем разобрать их не дожидаясь возвращения.
    let heldCapacity: Int
    private var held = false
    private var waiting = Set<String>()
    /// Накопленное за время в фоне разбирается здесь, не на главном потоке.
    static let catchUp = DispatchQueue(label: "FolderNews.catchUp", qos: .utility)

    init(heldCapacity: Int = 5000) {
        self.heldCapacity = heldCapacity
    }

    /// Пришло из журнала диска. Программа впереди — разбирается сразу. В фоне счётчики никто
    /// не видит, а панель свою слежку и вовсе усыпляет: пути только копятся, один путь — один
    /// раз, сколько бы его ни переписывали. Сборка проекта по соседству — это десятки тысяч
    /// событий, и раньше каждое проверялось на диске тут же, пока программа свёрнута.
    func arrive(_ paths: [String], now: Date = Date()) {
        lock.lock()
        guard held else {
            lock.unlock()
            note(paths, now: now)
            return
        }
        waiting.formUnion(paths)
        let overflow = waiting.count > heldCapacity ? Array(waiting) : nil
        if overflow != nil { waiting = [] }
        lock.unlock()
        if let overflow { note(overflow, now: now) }
    }

    /// Программа ушла в фон.
    func hold() {
        lock.lock()
        held = true
        lock.unlock()
    }

    /// Программа вернулась: накопленное разбирается одним разом. `queue: nil` — тут же.
    func release(on queue: DispatchQueue? = FolderNewsArrivals.catchUp) {
        lock.lock()
        held = false
        let paths = Array(waiting)
        waiting = []
        lock.unlock()
        guard !paths.isEmpty else { return }
        if let queue {
            queue.async { self.note(paths) }
        } else {
            note(paths)
        }
    }

    /// Сколько путей ждёт возвращения программы.
    var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting.count
    }
}

/// Что журналу нужно знать о файле — одним обращением к диску.
///
/// Раньше их было два: lstat (вид и флаг «скрытый») и URL.resourceValues (даты) — вместе
/// ~16 мкс на файл, почти всё время разбора события. getattrlist отдаёт то же за ~3,5 мкс.
/// Том, который так не отвечает, спрашивается по-старому.
enum FolderNewsDisk {
    enum Kind { case file, folder, other }

    struct Facts {
        let kind: Kind
        let isHidden: Bool
        /// Дата изменения содержимого.
        let modified: Date?
        /// Когда появился в своей папке; тома, которые этого не хранят, — nil.
        let added: Date?
    }

    enum Answer {
        case facts(Facts)
        /// На месте его нет.
        case gone
        case unknown
    }

    /// Ссылка не разыменовывается: сама она — не файл и не папка.
    static func facts(at path: String) -> Answer {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_ADDEDTIME)
        return withUnsafeTemporaryAllocation(byteCount: 128, alignment: 8) { buffer -> Answer in
            guard getattrlist(path, &list, buffer.baseAddress, buffer.count, UInt32(FSOPT_NOFOLLOW)) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { return .gone }
                return slowFacts(at: path)
            }
            // Ответ упакован подряд, по четыре байта: длина, что вернулось, затем сами
            // свойства в порядке их битов — вид, дата изменения, флаги, дата появления.
            let raw = UnsafeRawBufferPointer(buffer)
            let length = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            var offset = MemoryLayout<UInt32>.size
            let returned = raw.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
            offset += MemoryLayout<attribute_set_t>.size
            func has(_ attribute: Int32) -> Bool { returned.commonattr & attrgroup_t(attribute) != 0 }
            func take<T>(_ type: T.Type) -> T {
                defer { offset += MemoryLayout<T>.size }
                return raw.loadUnaligned(fromByteOffset: offset, as: type)
            }
            guard has(ATTR_CMN_OBJTYPE), has(ATTR_CMN_FLAGS) else { return slowFacts(at: path) }
            let type = take(UInt32.self)
            let modified: timespec? = has(ATTR_CMN_MODTIME) ? take(timespec.self) : nil
            let flags = take(UInt32.self)
            let added: timespec? = has(ATTR_CMN_ADDEDTIME) ? take(timespec.self) : nil
            guard offset <= length, length <= raw.count else { return slowFacts(at: path) }
            let kind: Kind = type == VREG.rawValue ? .file : type == VDIR.rawValue ? .folder : .other
            return .facts(Facts(kind: kind, isHidden: flags & UInt32(UF_HIDDEN) != 0,
                                modified: date(modified), added: date(added)))
        }
    }

    private static func date(_ time: timespec?) -> Date? {
        guard let time, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    /// По-старому: lstat и свойства через URL.
    static func slowFacts(at path: String) -> Answer {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .gone : .unknown }
        let kind: Kind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .folder
        default: kind = .other
        }
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        return .facts(Facts(kind: kind, isHidden: info.st_flags & UInt32(UF_HIDDEN) != 0,
                            modified: values?.contentModificationDate, added: values?.addedToDirectoryDate))
    }
}

/// Разбор пути из журнала байтами, без промежуточных строк.
enum FolderNewsPath {
    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")

    /// Есть ли на пути скрытая часть — имя с точки.
    static func hasHiddenPart(_ path: String) -> Bool {
        var path = path
        return path.withUTF8 { bytes in
            guard bytes.count > 1 else { return false }
            for index in 1..<bytes.count where bytes[index] == dot && bytes[index - 1] == slash { return true }
            return false
        }
    }

    /// Папки на пути к файлу, у которых в имени есть расширение, — только такая может
    /// оказаться пакетом (программа, документ .pages). Ближняя к файлу первой. Сам файл не в
    /// счёт; точка в начале или в конце имени — не расширение.
    static func foldersWithExtension(above path: String) -> [String] {
        var path = path
        return path.withUTF8 { bytes in
            var found: [String] = []
            var end = bytes.count          // конец текущей части пути
            var index = bytes.count - 1
            var isLast = true              // последняя часть — сам файл
            while index >= 0 {
                if bytes[index] == slash {
                    let start = index + 1
                    if !isLast, hasExtension(bytes, from: start, to: end) {
                        found.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[0..<end]), as: UTF8.self))
                    }
                    if end > start { isLast = false }
                    end = index
                }
                index -= 1
            }
            return found
        }
    }

    private static func hasExtension(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Bool {
        guard end - start >= 3 else { return false }
        for index in (start + 1)..<(end - 1) where bytes[index] == dot { return true }
        return false
    }
}

/// Слежка за деревом папки по журналу FSEvents: с истории за срок новизны — и дальше вживую, в
/// том числе пока программа в фоне (слежка панели тогда спит, а файлы бросают через Finder).
/// Что пришло, ушло, переименовано или перезаписано — в FolderNewsArrivals. Системные папки,
/// ~/Library и кэши (FileNewness) отсеиваются сразу, побайтно: в домашней папке это почти весь
/// журнал, и превращать каждый их путь в строку было бы зря.
final class FolderNewsStream {
    /// Журнал глубже суток не читается: сутки в домашней папке — это ~800 тысяч событий и
    /// секунды работы. Что старше — знает Spotlight.
    static let historyLimit: TimeInterval = 24 * 3600
    /// Брошенный файл виден в счётчике быстро: журнал отдаёт пачки через четверть секунды.
    static let latency: CFTimeInterval = 0.25

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
    /// Перезаписан на месте: журнал помечает это только так.
    private static let rewriteFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)

    private static let callback: FSEventStreamCallback = { _, _, count, rawPaths, flags, _ in
        let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var batch = Set<String>()
        let wanted = FolderNewsStream.arrivalFlags | FolderNewsStream.rewriteFlag
        let quick = FileNewness.excludedOverride == nil
        for index in 0..<count where flags[index] & wanted != 0 {
            // Скрытое по имени (.git, .build) — мимо, не превращая в строку: при сборке таких
            // событий тысячи.
            guard strstr(paths[index], "/.") == nil else { continue }
            if quick, FolderNewsStream.underExcludedRoot(paths[index]) { continue }
            let path = String(cString: paths[index])
            guard !FileNewness.isExcluded(path) else { continue }
            batch.insert(path)
        }
        if !batch.isEmpty { FolderNewsArrivals.shared.arrive(Array(batch)) }
    }

    /// Исключённые корни байтами, с косой чертой на конце.
    private static let excludedPrefixes: [[UInt8]] = FileNewness.excludedRoots.map { Array(($0 + "/").utf8) }

    /// Путь журнала лежит в системной папке или ~/Library — без строки, сравнением байтов.
    static func underExcludedRoot(_ path: UnsafePointer<CChar>) -> Bool {
        let length = strlen(path)
        return excludedPrefixes.contains { prefix in
            prefix.count <= length && prefix.withUnsafeBufferPointer { memcmp(path, $0.baseAddress, prefix.count) == 0 }
        }
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
