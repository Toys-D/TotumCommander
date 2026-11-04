import Foundation

/// Местная копия файла, лежащего на сервере или в облаке.
///
/// Ни просмотрщик, ни системная программа не умеют читать «/папка/снимок.png» на Google
/// Drive: для них файл — это файл на диске. Раньше им отдавали удалённый путь как есть, и
/// человек получал от Finder «не удаётся найти файл» — при том, что файл прекрасно виден
/// в панели. Здесь файл сначала скачивается во временную папку, и дальше всё работает
/// с обычной копией.
///
/// Копии живут до выхода из программы и переиспользуются: листая папку со снимками туда-сюда,
/// человек не должен качать одно и то же по десять раз. Признак «та же копия» — совпадение
/// размера: имя и путь уже учтены в адресе копии.
@MainActor
final class RemoteFileCache {

    static let shared = RemoteFileCache()

    /// Больше сотни мегабайт молча не качаем: столько ждать ради взгляда одним глазом
    /// человек не просил. Всё, что крупнее, требует его согласия.
    static let quietLimit: Int64 = 100 << 20

    private var folder: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TotumCommander-remote", isDirectory: true)
    }

    /// Где будет лежать копия этого файла.
    ///
    /// Путь внутри хранилища кодируется в имя папки, а не раскладывается по вложенным:
    /// у облаков в именах встречается что угодно, включая слэши в неожиданных местах.
    func placeFor(_ item: FileItem, connectionID: UUID) -> URL {
        let key = Self.fingerprint(item.path)
        return folder
            .appendingPathComponent(connectionID.uuidString, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(item.name)
    }

    /// Короткий и устойчивый отпечаток пути. Просто взять имя нельзя: два «снимок.png»
    /// из разных папок затирали бы друг друга.
    static func fingerprint(_ path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(path.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    /// Есть ли уже готовая копия — та же, а не тёзка.
    ///
    /// Судим по времени правки, а не только по размеру. Документы Google (Docs, Sheets,
    /// Slides) размера не имеют вовсе: файл собирается из них на лету при выгрузке, и
    /// Диск заранее не знает, сколько получится. Сравнение размеров у таких документов не
    /// сходилось никогда — и каждый взгляд запускал выгрузку заново, а она у Диска стоит
    /// двадцать секунд.
    func readyCopy(of item: FileItem, connectionID: UUID) -> String? {
        let place = placeFor(item, connectionID: connectionID)
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: place.path) else { return nil }
        guard let stamp = attributes[.modificationDate] as? Date,
              abs(stamp.timeIntervalSince(item.dateModified)) < 1 else { return nil }
        // Размер, если он известен, обязан сойтись тоже.
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        if item.size > 0, size != Int64(item.size) { return nil }
        return place.path
    }

    /// Скачать файл во временную копию (или отдать уже скачанную).
    func localCopy(of item: FileItem, session: RemoteSession,
                   progress: @escaping (Int64, Int64) -> Bool = { _, _ in false })
    async throws -> String {
        if let ready = readyCopy(of: item, connectionID: session.connection.id) {
            return ready
        }
        let place = placeFor(item, connectionID: session.connection.id)
        try FileManager.default.createDirectory(
            at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Недокачанное под настоящим именем — хуже, чем ничего: в следующий раз мы приняли бы
        // огрызок за готовую копию, если бы размер случайно сошёлся.
        try? FileManager.default.removeItem(at: place)

        try await session.fileSystem.download(remotePath: item.path, to: place.path,
                                              progress: progress)
        // Копия наследует время правки исходника — по нему её потом и узнают.
        try? FileManager.default.setAttributes([.modificationDate: item.dateModified],
                                               ofItemAtPath: place.path)
        return place.path
    }

    /// Сколько панелей сейчас смотрят в это подключение. Одно и то же хранилище часто
    /// открыто в обеих панелях сразу, и уход из одной не должен уносить копии из-под другой.
    private var holders: [UUID: Int] = [:]

    /// Панель вошла в хранилище.
    func hold(connectionID: UUID) {
        holders[connectionID, default: 0] += 1
    }

    /// Панель ушла из хранилища. Последняя уходящая уносит с собой и копии: человек
    /// отключился — на диске от чужих файлов ничего не остаётся.
    func release(connectionID: UUID) {
        guard let count = holders[connectionID] else { return }
        if count > 1 {
            holders[connectionID] = count - 1
            return
        }
        holders.removeValue(forKey: connectionID)
        forget(connectionID: connectionID)
    }

    /// Забыть копии одного подключения — например, когда человек от него отключился.
    func forget(connectionID: UUID) {
        try? FileManager.default.removeItem(
            at: folder.appendingPathComponent(connectionID.uuidString))
    }

    /// Убрать всё. Так уходит программа: копии чужих файлов не должны переживать сеанс.
    nonisolated static func cleanupAll() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.removeItem(
            at: temp.appendingPathComponent("TotumCommander-remote", isDirectory: true))
        // И записи помощника: они пишутся на каждый его запуск и сами не убираются.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix("totum-rclone-") && name.hasSuffix(".log") {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }
}

/// Просьба остановиться, живущая отдельно от вида.
///
/// О ходе переноса спрашивают из того потока, где он идёт, а состояние SwiftUI оттуда
/// читать нельзя. Коробку — можно: она за замком и никому не принадлежит.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var raised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func raise() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
