import Foundation

/// A place inside a document.
///
/// A PDF page is a fixed thing, so its number is enough. A book's pages are not: change the
/// window width or the type size and they renumber — which is why a book also carries an
/// anchor into the text itself.
struct ReaderLocation: Codable, Equatable, Hashable, Sendable {
    var page: Int
    var chapter: Int?
    var anchor: String?

    init(page: Int, chapter: Int? = nil, anchor: String? = nil) {
        self.page = page
        self.chapter = chapter
        self.anchor = anchor
    }
}

/// One bookmark: where, and what it was called when it was made.
struct ReaderMark: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var location: ReaderLocation
    var label: String
    var createdAt: Date
    /// Название места без номера — глава, раздел, заголовок страницы. Хранится отдельно,
    /// чтобы имя можно было собрать заново, когда номера страниц поедут: указали «эта
    /// страница первая» — и закладка обязана называться так же, как счётчик.
    var autoTitle: String?
    /// Человек назвал закладку сам. Такое имя автоматика не трогает уже никогда.
    var isCustom: Bool

    init(id: UUID = UUID(), location: ReaderLocation, label: String,
         createdAt: Date = Date(), autoTitle: String? = nil, isCustom: Bool = false) {
        self.id = id
        self.location = location
        self.label = label
        self.createdAt = createdAt
        self.autoTitle = autoTitle
        self.isCustom = isCustom
    }

    enum CodingKeys: String, CodingKey {
        case id, location, label, createdAt, autoTitle, isCustom
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        location = try box.decode(ReaderLocation.self, forKey: .location)
        label = try box.decode(String.self, forKey: .label)
        createdAt = try box.decode(Date.self, forKey: .createdAt)
        autoTitle = try box.decodeIfPresent(String.self, forKey: .autoTitle)
        isCustom = try box.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }
}

/// Everything remembered about one document.
struct ReaderRecord: Codable, Equatable, Sendable {
    var fileSize: UInt64
    var modifiedAt: Date
    var touchedAt: Date
    var lastPosition: ReaderLocation?
    var marks: [ReaderMark]
    /// Лист, на котором напечатана страница 1. У сканов перед ней лежат обложка, титул и
    /// оборот титула — и «стр. 9 из 282» расходится с тем, что человек видит в книге.
    var numberingStart: Int?

    init(fileSize: UInt64, modifiedAt: Date, touchedAt: Date,
         lastPosition: ReaderLocation? = nil, marks: [ReaderMark] = [],
         numberingStart: Int? = nil) {
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.touchedAt = touchedAt
        self.lastPosition = lastPosition
        self.marks = marks
        self.numberingStart = numberingStart
    }
}

/// Bookmarks and "where I left off", for any document with more than one page.
///
/// Tied to the file by PATH, checked by size and modification date. Not by content: hashing a
/// 700 MB PDF on every open costs more than the feature is worth. Not by path alone either: a
/// bookmark that silently lands on a different file is a lie, so when the file no longer
/// matches, its marks are hidden — but NOT deleted, because a file restored from a backup
/// should bring them back.
final class ReaderMarksStore: @unchecked Sendable {

    static let shared = ReaderMarksStore()

    private let fileURL: URL
    private let lock = NSLock()
    private var records: [String: ReaderRecord] = [:]
    private var loaded = false
    private var saveWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.fcxl.reader-marks")

    /// Beyond this the file is trimmed, oldest touch first.
    private let capacity = 2000

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
                .appendingPathComponent("TotumCommander", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("reader-marks.json")
        }
    }

    // MARK: - Reading

    func marks(for path: String) -> [ReaderMark] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard let record = records[key(for: path)], matches(record, path: path) else { return [] }
        return record.marks.sorted { $0.createdAt < $1.createdAt }
    }

    func lastPosition(for path: String) -> ReaderLocation? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard let record = records[key(for: path)], matches(record, path: path) else { return nil }
        return record.lastPosition
    }

    // MARK: - Writing

    /// Put a bookmark here, or take away the one that is already here. Answers true when a
    /// mark was added.
    @discardableResult
    func toggleMark(at location: ReaderLocation, label: String,
                    autoTitle: String? = nil, for path: String) -> Bool {
        guard Self.isRecordable(path: path) else { return false }
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var record = current(for: path)
        if let index = record.marks.firstIndex(where: { $0.location == location }) {
            record.marks.remove(at: index)
            store(record, for: path)
            return false
        }
        record.marks.append(ReaderMark(location: location, label: label,
                                       autoTitle: autoTitle))
        store(record, for: path)
        return true
    }

    /// Переименовать закладку рукой. Имя, данное человеком, дороже любого угаданного: с
    /// этого момента ни уточнение названия, ни смена нумерации его не трогают.
    func renameMark(id: UUID, to label: String, for path: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var record = current(for: path)
        guard let index = record.marks.firstIndex(where: { $0.id == id }) else { return }
        record.marks[index].label = label
        record.marks[index].isCustom = true
        store(record, for: path)
    }

    /// Уточнить автоматическое имя — название страницы пришло позже, чем сама закладка.
    func updateAutoName(id: UUID, label: String, title: String?, for path: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var record = current(for: path)
        guard let index = record.marks.firstIndex(where: { $0.id == id }),
              !record.marks[index].isCustom else { return }
        record.marks[index].label = label
        record.marks[index].autoTitle = title
        store(record, for: path)
    }

    /// Пересобрать автоматические имена — номера страниц поехали.
    ///
    /// Без этого счётчик и закладка на одном и том же месте начинали говорить разное:
    /// «Страница 9» в списке против «Страница 6» в шапке.
    func renumberMarks(for path: String, naming: (ReaderMark) -> String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var record = current(for: path)
        guard !record.marks.isEmpty else { return }
        var changed = false
        for index in record.marks.indices where !record.marks[index].isCustom {
            let name = naming(record.marks[index])
            if record.marks[index].label != name {
                record.marks[index].label = name
                changed = true
            }
        }
        guard changed else { return }
        store(record, for: path)
    }

    /// С какого листа начинается напечатанная нумерация. nil — про этот файл ещё не решали.
    func numberingStart(for path: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard let record = records[key(for: path)], matches(record, path: path) else { return nil }
        return record.numberingStart
    }

    func setNumberingStart(_ index: Int?, for path: String) {
        guard Self.isRecordable(path: path) else { return }
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var record = current(for: path)
        record.numberingStart = index
        store(record, for: path)
    }

    func removeMark(id: UUID, for path: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var record = current(for: path)
        record.marks.removeAll { $0.id == id }
        store(record, for: path)
    }

    func removeAllMarks(for path: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var record = current(for: path)
        record.marks = []
        store(record, for: path)
    }

    func rememberPosition(_ location: ReaderLocation, for path: String) {
        guard Self.isRecordable(path: path) else { return }
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var record = current(for: path)
        record.lastPosition = location
        store(record, for: path)
    }

    /// A file pulled out of an archive for a look lives in a temporary folder and will be gone
    /// in a minute — a bookmark on it is rubbish from the moment it is made.
    /// Instance-side twin, for call sites that already hold the store.
    func isRecordablePath(_ path: String) -> Bool { Self.isRecordable(path: path) }

    static func isRecordable(path: String) -> Bool {
        // Only the throwaway copies the viewer makes when looking inside an archive are
        // refused. Refusing the whole temporary folder was too wide a net: a book opened
        // from anywhere else in there is an ordinary file, and its bookmark is worth keeping.
        !path.contains("/fcxl_archive_view") && !path.contains("/fcxl_preview")
    }

    func flush() {
        saveWorkItem?.cancel()
        lock.lock(); defer { lock.unlock() }
        writeLocked()
    }

    // MARK: - Innards

    private func key(for path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func current(for path: String) -> ReaderRecord {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date) ?? Date()
        if let existing = records[key(for: path)], matches(existing, path: path) {
            var refreshed = existing
            refreshed.touchedAt = Date()
            return refreshed
        }
        return ReaderRecord(fileSize: size, modifiedAt: modified, touchedAt: Date(),
                            lastPosition: nil, marks: [])
    }

    private func matches(_ record: ReaderRecord, path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else { return false }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        return record.fileSize == size
            && abs(record.modifiedAt.timeIntervalSince(modified)) < 1
    }

    private func store(_ record: ReaderRecord, for path: String) {
        var fresh = record
        fresh.touchedAt = Date()
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        fresh.fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? fresh.fileSize
        fresh.modifiedAt = (attributes?[.modificationDate] as? Date) ?? fresh.modifiedAt
        records[key(for: path)] = fresh
        scheduleSave()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        records = (try? JSONDecoder().decode([String: ReaderRecord].self, from: data)) ?? [:]
    }

    /// Written a couple of seconds late: turning pages must not hammer the disk.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.writeLocked()
        }
        saveWorkItem = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func writeLocked() {
        if records.count > capacity {
            let survivors = records.sorted { $0.value.touchedAt > $1.value.touchedAt }
                .prefix(capacity)
            records = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
