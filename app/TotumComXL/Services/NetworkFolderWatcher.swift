import Foundation

/// Как панель следит за открытой папкой — по тому, где папка лежит.
enum FolderWatchMode: Equatable {
    /// Журнал диска (FSEvents) — быстрые местные тома.
    case journal
    /// NetworkFolderWatcher — сетевой том: о правках на самом сервере журнал молчит.
    case network
    /// Не следить: архив, медленный внешний диск (экономия) — там перечитывают переход в папку,
    /// возвращение в программу и собственные операции.
    case none

    static func mode(insideArchive: Bool, slowVolume: Bool, networkVolume: Bool) -> FolderWatchMode {
        if insideArchive { return .none }
        if networkVolume { return .network }
        return slowVolume ? .none : .journal
    }
}

/// Слежка за папкой сетевого тома (SMB, AFP, NFS).
///
/// Журнал диска (FSEvents) знает только сделанное с этого Mac: файл, положенный в ту же папку на
/// самом сервере, панель не показывала, пока в папку не войти заново. Здесь два способа сразу.
/// kqueue на саму папку: macOS при этом просит у сервера уведомления об изменениях (SMB change
/// notify) и передаёт их сразу — так обновляет сетевые папки и Finder. И тихая сверка даты
/// изменения папки раз в несколько секунд — для серверов, которые уведомлений не шлют. Папка
/// открыта «только для событий» (O_EVTONLY): том извлекается, будто слежки нет. Всё — на своей
/// очереди: зависший сервер не держит ни интерфейс, ни остановку.
final class NetworkFolderWatcher: @unchecked Sendable {
    static let pollInterval: TimeInterval = 4

    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "NetworkFolderWatcher", qos: .utility)
    // Только на `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var stamp: Stamp?
    private var stopped = false

    /// Дата изменения папки: на сервере она сдвигается, когда в папке что-то появилось, исчезло
    /// или переименовано.
    struct Stamp: Equatable {
        let seconds: Int
        let nanoseconds: Int
    }

    /// `events: false` — только сверка: так проверяется запасной путь.
    init(path: String, pollInterval: TimeInterval = NetworkFolderWatcher.pollInterval, events: Bool = true,
         onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
        queue.async { [self] in start(pollInterval: pollInterval, events: events) }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            source?.cancel()
            source = nil
            timer?.cancel()
            timer = nil
        }
    }

    deinit {
        source?.cancel()
        timer?.cancel()
    }

    static func stamp(of path: String) -> Stamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Stamp(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    private func start(pollInterval: TimeInterval, events: Bool) {
        guard !stopped else { return }
        stamp = Self.stamp(of: path)
        if events {
            let descriptor = open(path, O_EVTONLY)
            if descriptor >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .delete, .rename, .link, .extend, .revoke],
                    queue: queue)
                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    // Том отключили — об этом скажет своя дорога («Диск отключён»), не слежка.
                    if source.data.contains(.revoke) {
                        source.cancel()
                        self.source = nil
                        return
                    }
                    self.changed()
                }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                self.source = source
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval,
                       leeway: .milliseconds(Int(pollInterval * 250)))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        guard !stopped else { return }
        let now = Self.stamp(of: path)
        guard now != stamp else { return }
        stamp = now
        onChange()
    }

    private func changed() {
        guard !stopped else { return }
        stamp = Self.stamp(of: path)
        onChange()
    }
}
