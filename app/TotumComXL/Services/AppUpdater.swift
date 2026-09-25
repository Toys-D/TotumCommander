import AppKit
import CryptoKit
import Foundation
import os

/// Обновление в один щелчок: скачать образ выпуска с GitHub, сверить сумму, подменить
/// программу в её папке и перезапуститься уже новой.
///
/// Раньше «О программе» давало только ссылку: скачать, открыть образ, перетащить, подтвердить
/// замену, запустить заново. Всё это и так делалось руками одинаково — теперь делает
/// программа. Серверов и ключей нет: образ и файл сумм лежат в GitHub Releases, куда их
/// кладёт выпуск, и сумма сверяется до установки.
///
/// Решения — чистые функции в `UpdatePlan`, шаги с диском и сетью — в `UpdateSteps`,
/// оркестр и состояние для окна — в `AppUpdater`.
enum UpdatePlan {

    /// Что скачивать: образ и файл сумм того же выпуска.
    struct Assets: Equatable {
        let dmg: URL
        let dmgName: String
        let sums: URL
    }

    /// Из ответа GitHub `releases/latest`: первый `.dmg` и `SHA256SUMS.txt`. Без файла сумм
    /// установки не будет — образ без проверки не ставится.
    static func assets(from data: Data) -> Assets? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["assets"] as? [[String: Any]] else { return nil }
        var dmg: (URL, String)?
        var sums: URL?
        for asset in list {
            guard let name = asset["name"] as? String,
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
            else { continue }
            if name.lowercased().hasSuffix(".dmg"), dmg == nil { dmg = (url, name) }
            if name == "SHA256SUMS.txt" { sums = url }
        }
        guard let dmg, let sums else { return nil }
        return Assets(dmg: dmg.0, dmgName: dmg.1, sums: sums)
    }

    /// Сумма для файла из `SHA256SUMS.txt`: строки вида `хеш  имя` (или `хеш *имя`).
    static func expectedHash(in sums: String, for fileName: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
            guard parts.count >= 2 else { continue }
            var name = parts[1...].joined(separator: " ")
            if name.hasPrefix("*") { name.removeFirst() }
            if name == fileName { return parts[0].lowercased() }
        }
        return nil
    }

    /// SHA-256 файла, читая кусками: образ — десятки мегабайт.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Почему обновиться на месте нельзя.
    enum Obstacle: Equatable {
        /// Запущен голый исполняемый файл, не `.app`.
        case notABundle
        /// macOS запустила программу из временной копии (App Translocation): настоящего
        /// места мы не знаем.
        case translocated
        /// Программа запущена прямо из образа.
        case readOnlyVolume
        /// Папку или сам бандл менять нельзя — чужой владелец.
        case notWritable
    }

    static func obstacle(bundleURL: URL, fileManager: FileManager = .default) -> Obstacle? {
        guard bundleURL.pathExtension == "app" else { return .notABundle }
        if bundleURL.path.contains("/AppTranslocation/") { return .translocated }
        if (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return .readOnlyVolume
        }
        let parent = bundleURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path),
              fileManager.isWritableFile(atPath: bundleURL.path) else { return .notWritable }
        return nil
    }

    /// Куда класть новую копию и куда отставить старую: рядом с бандлом, на том же томе, чтобы
    /// подмена была переименованием, а не копированием.
    static func stagingURLs(for bundle: URL, tag: String) -> (incoming: URL, retired: URL) {
        let parent = bundle.deletingLastPathComponent()
        let name = bundle.lastPathComponent
        let safeTag = tag.filter { $0.isLetter || $0.isNumber || $0 == "." }
        return (parent.appendingPathComponent(".\(name).incoming-\(safeTag)"),
                parent.appendingPathComponent(".\(name).retired-\(ProcessInfo.processInfo.processIdentifier)"))
    }
}

enum UpdateError: Error, Equatable {
    case noAssets
    case hashMismatch
    case noAppInImage
    case tool(String, Int32)
    case badCopy
}

/// Шаги с диском: копирование, подключение образа, подмена. Без главного потока.
enum UpdateSteps {

    /// Что делать со старой копией после подмены.
    enum Retire {
        /// В Корзину — как делает всякий обновлятор: копия остаётся под рукой.
        case trash
        /// Удалить насовсем — для проверок, чтобы не трогать Корзину человека.
        case delete
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.tool((tool as NSString).lastPathComponent, process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Подключить образ тихо, в свою папку. Возвращает точку монтирования.
    static func mount(dmg: URL, at mountPoint: URL) throws -> URL {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                     "-mountpoint", mountPoint.path])
        return mountPoint
    }

    static func detach(_ mountPoint: URL) {
        _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
    }

    /// Первый `.app` в корне образа.
    static func appInside(_ mountPoint: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: mountPoint,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    /// Подменить `bundle` копией `newApp`: `ditto` в соседнюю папку, снять карантин, два
    /// переименования на одном томе, старую копию — в Корзину. Сорвалось второе
    /// переименование — старая возвращается на место.
    static func install(from newApp: URL, over bundle: URL, tag: String, retire: Retire,
                        fileManager: FileManager = .default) throws {
        let staging = UpdatePlan.stagingURLs(for: bundle, tag: tag)
        try? fileManager.removeItem(at: staging.incoming)
        try run("/usr/bin/ditto", [newApp.path, staging.incoming.path])
        // Скачано самой программой, карантина быть не должно — но снять его дешевле, чем
        // объяснять человеку «правый щелчок ▸ Открыть» после каждого обновления.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.incoming.path])
        guard fileManager.fileExists(atPath: staging.incoming.appendingPathComponent("Contents/MacOS").path)
        else {
            try? fileManager.removeItem(at: staging.incoming)
            throw UpdateError.badCopy
        }

        try? fileManager.removeItem(at: staging.retired)
        try fileManager.moveItem(at: bundle, to: staging.retired)
        do {
            try fileManager.moveItem(at: staging.incoming, to: bundle)
        } catch {
            try? fileManager.moveItem(at: staging.retired, to: bundle)
            throw error
        }
        switch retire {
        case .trash:
            if (try? fileManager.trashItem(at: staging.retired, resultingItemURL: nil)) == nil {
                try? fileManager.removeItem(at: staging.retired)
            }
        case .delete:
            try? fileManager.removeItem(at: staging.retired)
        }
    }

    /// Скачать файл с ходом дела. Настоящая задача загрузки: ход приходит от системы, файл
    /// не проходит через память.
    static func download(_ url: URL, to destination: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("TotumCommander", forHTTPHeaderField: "User-Agent")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // Перенос — здесь же, до возврата: временный файл системы живёт только до конца
            // этого вызова.
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                if let http = downloadTask.response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    finish(.failure(URLError(.badServerResponse)))
                } else {
                    finish(.success(()))
                }
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard !finished, let continuation else { return }
            finished = true
            continuation.resume(with: result)
        }
    }
}

/// Оркестр обновления и его состояние для «О программе».
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    enum Stage: Equatable {
        case idle
        case downloading(Double)
        case verifying
        case installing
        case relaunching
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.fcxl.filecommander",
                                category: "Updates")

    var isBusy: Bool {
        switch stage {
        case .idle, .failed: return false
        default: return true
        }
    }

    /// Бандл, который обновляем: тот, что запущен на самом деле, а не тот, откуда читаются
    /// строки — после переноса верен только живой путь.
    static var liveBundleURL: URL {
        if let live = AppResources.liveExecutablePath(),
           let app = AppResources.liveRoots(executablePath: live).app { return app }
        return Bundle.main.bundleURL
    }

    static func message(for obstacle: UpdatePlan.Obstacle) -> String {
        switch obstacle {
        case .notABundle: return L("updates.obstacle.notABundle")
        case .translocated: return L("updates.obstacle.translocated")
        case .readOnlyVolume: return L("updates.obstacle.readOnly")
        case .notWritable: return L("updates.obstacle.notWritable")
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case UpdateError.noAssets: return L("updates.error.assets")
        case UpdateError.hashMismatch: return L("updates.error.hash")
        case UpdateError.noAppInImage, UpdateError.badCopy: return L("updates.error.image")
        case UpdateError.tool(let name, let code):
            return String(format: L("updates.error.tool"), name, code)
        default: return String(format: L("updates.error.generic"), error.localizedDescription)
        }
    }

    /// Скачать, проверить, подменить, перезапуститься. Любой срыв — в `stage = .failed`
    /// с человеческим объяснением; программа при этом остаётся прежней и целой.
    func update(to release: UpdateChecker.Release) async {
        guard !isBusy else { return }
        let bundle = Self.liveBundleURL
        if let obstacle = UpdatePlan.obstacle(bundleURL: bundle) {
            stage = .failed(Self.message(for: obstacle))
            return
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fcxl-update-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        var mountPoint: URL?
        defer {
            if let mountPoint { UpdateSteps.detach(mountPoint) }
            try? FileManager.default.removeItem(at: work)
        }
        do {
            stage = .downloading(0)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let answer = try await UpdateChecker.fetchFromGitHub()
            guard let assets = UpdatePlan.assets(from: answer) else { throw UpdateError.noAssets }
            let dmg = work.appendingPathComponent(assets.dmgName)
            try await UpdateSteps.download(assets.dmg, to: dmg) { fraction in
                Task { @MainActor in
                    if case .downloading = self.stage { self.stage = .downloading(fraction) }
                }
            }

            stage = .verifying
            let (sumsData, _) = try await URLSession.shared.data(from: assets.sums)
            let expected = UpdatePlan.expectedHash(in: String(decoding: sumsData, as: UTF8.self),
                                                   for: assets.dmgName)
            let actual = try await Task.detached { try UpdatePlan.sha256(of: dmg) }.value
            guard let expected, expected == actual else { throw UpdateError.hashMismatch }

            stage = .installing
            let mount = work.appendingPathComponent("image", isDirectory: true)
            let tag = release.version
            try await Task.detached {
                _ = try UpdateSteps.mount(dmg: dmg, at: mount)
            }.value
            mountPoint = mount
            guard let newApp = UpdateSteps.appInside(mount) else { throw UpdateError.noAppInImage }
            try await Task.detached {
                try UpdateSteps.install(from: newApp, over: bundle, tag: tag, retire: .trash)
            }.value
            UpdateSteps.detach(mount)
            mountPoint = nil
            logger.notice("update.installed version=\(tag, privacy: .public) at=\(bundle.path, privacy: .public)")

            stage = .relaunching
            if !AppLanguage.relaunchApp() { stage = .failed(L("updates.error.relaunch")) }
        } catch {
            logger.error("update.failed: \(error.localizedDescription, privacy: .public)")
            stage = .failed(Self.message(for: error))
        }
    }

    /// Снова в покой — после срыва, чтобы кнопка вернулась.
    func reset() {
        if case .failed = stage { stage = .idle }
    }
}
